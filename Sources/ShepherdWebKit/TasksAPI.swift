import Foundation
import ShepherdCore
import ShepherdGhostty
import ShepherdTasks

private struct SessionNoteWire: Encodable {
    let id: String
    let cwd: String
    let started: String
    let title: String?
}

private struct ChildWire: Encodable {
    let id: Int
    let title: String
    let status: String
}

private struct PlanStepWire: Encodable {
    let text: String
    let done: Bool
}

private struct TaskWire: Encodable {
    let id: Int
    let title: String
    let objective: String?
    let projectPath: String?
    let status: String
    let progressDone: Int
    let progressTotal: Int
    let sessionIDs: [String]
    let branch: String?
    let pr: String?
    let updated: String?
    var finishing = false
    let parentID: Int?
    var subtasksDone = 0
    var subtasksTotal = 0
    /// Only in the detail response.
    var sessionNotes: [SessionNoteWire]?
    var children: [ChildWire]?
    var plan: [PlanStepWire]?
    var log: [String]?
    var result: String?
    var handoff: String?
    var notes: [String]?
    var workspace: String?

    enum CodingKeys: String, CodingKey {
        case id, title, objective, status, branch, pr, updated, plan, log, finishing, result, children, handoff, notes, workspace
        case parentID = "parent_id"
        case subtasksDone = "subtasks_done"
        case subtasksTotal = "subtasks_total"
        case sessionNotes = "session_notes"
        case projectPath = "project_path"
        case progressDone = "progress_done"
        case progressTotal = "progress_total"
        case sessionIDs = "session_ids"
    }
}

private func wire(_ task: TaskFile, detail: Bool = false, workspace: URL? = nil, finishing: Bool = false, children: [TaskFile] = []) -> TaskWire {
    let progress = task.progress
    var out = TaskWire(
        id: task.id, title: task.title, objective: task.objective, projectPath: task.projectPath, status: task.status.rawValue,
        progressDone: progress.done, progressTotal: progress.total, sessionIDs: task.sessions, branch: task.branch, pr: task.pr,
        updated: task.updated, parentID: task.parent)
    out.subtasksTotal = children.count
    out.subtasksDone = children.filter { $0.status == .done }.count
    out.finishing = finishing
    out.result = task.result
    if detail {
        out.plan = task.plan.map { PlanStepWire(text: $0.text, done: $0.done) }
        out.log = Array(task.logEntries.suffix(40))
        out.handoff = task.handoff
        out.notes = task.notes.isEmpty ? nil : Array(task.notes.suffix(40))
        if let workspace, FileManager.default.fileExists(atPath: workspace.path) { out.workspace = workspace.path }
        out.sessionNotes = task.sessionNotes.map { SessionNoteWire(id: $0.id, cwd: $0.cwd, started: $0.started, title: $0.title) }
        out.children = children.map { ChildWire(id: $0.id, title: $0.title, status: $0.status.rawValue) }
    }
    return out
}

private struct ErrorWire: Encodable { let error: String }
private struct SearchHitWire: Encodable {
    let id: Int
    let title: String
    let status: String
    let updated: String?
    /// Where the words were found ("title", "notes", ...).
    let found: String
    let sessions: Int
}
private struct SessionRef: Encodable {
    let sessionID: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}
private struct NewTaskBody: Decodable {
    let title: String
    let objective: String?
    let projectPath: String?
    let parentID: Int?
    enum CodingKeys: String, CodingKey { case title, objective, projectPath = "project_path", parentID = "parent_id" }
}
private struct ResumeBody: Decodable {
    let sessionID: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}
private struct StatusBody: Decodable { let status: String }
private struct EditBody: Decodable {
    let title: String?
    let objective: String?
}
private struct FromSessionBody: Decodable {
    let sessionID: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}

/// The task board's data and actions. Tasks live in files (`ShepherdTasks`); this serves them to the dashboard page and
/// does what the panel's Tasks tab does: start a task's session, or go to it when it has one. The server's rule is the
/// same as for the phone: a session only starts in a folder the server offers (`startTargets`).
/// Tasks whose sessions are being asked to write a result before they are ended. Shared by every copy of `TasksAPI`.
actor FinishCoordinator {
    private var running: Set<Int> = []
    func begin(_ id: Int) -> Bool { running.insert(id).inserted }
    func end(_ id: Int) { running.remove(id) }
    func isFinishing(_ id: Int) -> Bool { running.contains(id) }
    func all() -> Set<Int> { running }
}

struct TasksAPI {
    let backend: any SessionBackend
    var finisher = FinishCoordinator()
    /// How long a session gets to write its result before Done falls back to its own summary line.
    var finishWait: TimeInterval = 60
    var home = FileManager.default.homeDirectoryForCurrentUser
    var store: @Sendable () -> TaskStore = { TaskStore() }
    var config: @Sendable () -> ShepherdConfig = { ShepherdConfig.load() }
    /// Done tasks shown on the board (most recently changed first).
    var doneLimit = 15

    func handles(_ path: String) -> Bool { path == "/api/tasks" || path.hasPrefix("/api/tasks/") }

    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        let parts = request.path.split(separator: "/").map(String.init)
        do {
            if request.method == "GET", parts == ["api", "tasks"] { return try await list() }
            if request.method == "POST", parts == ["api", "tasks"] { return try create(request) }
            if request.method == "GET", parts == ["api", "tasks", "search"] { return search(request.query["q"] ?? "") }
            if request.method == "POST", parts == ["api", "tasks", "from-session"] { return try await promote(request) }
            if parts.count >= 3, parts[0] == "api", parts[1] == "tasks", let id = Int(parts[2]) {
                if request.method == "GET", parts.count == 3 { return try await detail(id) }
                if request.method == "POST", parts.count == 4, parts[3] == "status" { return try setStatus(id, request) }
                if request.method == "POST", parts.count == 4, parts[3] == "start" { return try await start(id) }
                if request.method == "POST", parts.count == 4, parts[3] == "edit" { return try edit(id, request) }
                if request.method == "POST", parts.count == 4, parts[3] == "delete" { return try await delete(id) }
                if request.method == "POST", parts.count == 4, parts[3] == "done" { return try await finish(id, immediately: request.query["now"] == "1", includeChildren: request.query["children"] == "1") }
                if request.method == "POST", parts.count == 4, parts[3] == "reopen" { return try reopen(id) }
                if request.method == "POST", parts.count == 4, parts[3] == "pickup" { return try await pickUp(id) }
                if request.method == "POST", parts.count == 4, parts[3] == "resume" { return try await resume(id, request) }
                if request.method == "GET", parts.count == 4, parts[3] == "transcript" { return transcript(id, request) }
            }
            return .notFound()
        } catch let error as TaskError {
            return fail(error.description, 400)
        } catch let error as BackendError {
            return fail("\(error)", 502)
        } catch {
            return fail("\(error)", 400)
        }
    }

    private func fail(_ message: String, _ status: Int) -> HTTPServer.Response {
        .json((try? JSONEncoder().encode(ErrorWire(error: message))) ?? Data(), status: status)
    }

    private func list() async throws -> HTTPServer.Response {
        let finishing = await finisher.all()
        let all = store().list()
        let open = all.filter { $0.status != .done }
        let done = all.filter { $0.status == .done }.sorted { ($0.updated ?? "") > ($1.updated ?? "") }.prefix(doneLimit)
        let wires = (open + done).map { task in wire(task, finishing: finishing.contains(task.id), children: all.filter { $0.parent == task.id }) }
        return .json(try JSONEncoder().encode(wires))
    }

    /// Every task, done ones included, whose text holds all the words: for finding an old task to bring back.
    private func search(_ query: String) -> HTTPServer.Response {
        let found = store().list().compactMap { task -> (TaskFile, String, Bool)? in
            guard let hit = task.search(query) else { return nil }
            return (task, hit.field, hit.titleMatch)
        }
        .sorted { ($0.2 ? 1 : 0, $0.0.updated ?? "") > ($1.2 ? 1 : 0, $1.0.updated ?? "") }
        .prefix(30)
        let wires = found.map { SearchHitWire(id: $0.0.id, title: $0.0.title, status: $0.0.status.rawValue, updated: $0.0.updated, found: $0.1, sessions: $0.0.sessions.count) }
        return .json((try? JSONEncoder().encode(wires)) ?? Data("[]".utf8))
    }

    private func detail(_ id: Int) async throws -> HTTPServer.Response {
        guard let task = store().get(id) else { return fail("no task \(id)", 404) }
        return .json(try JSONEncoder().encode(wire(task, detail: true, workspace: store().workspaceDirectory(for: id), finishing: await finisher.isFinishing(id), children: store().children(of: id))))
    }

    private func create(_ request: HTTPServer.Request) throws -> HTTPServer.Response {
        let body = try JSONDecoder().decode(NewTaskBody.self, from: request.body)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else { return fail("a task needs a title of up to 200 characters", 400) }
        var project: String?
        if let wanted = body.projectPath, !wanted.isEmpty {
            guard let target = startTargets(config: config()).first(where: { $0.path == canonicalPath(wanted) }) else {
                return fail("not a project Shepherd offers", 400)
            }
            project = target.path
        }
        if project == nil, let parent = body.parentID, let inherited = store().get(parent)?.projectPath { project = inherited }
        let objective = body.objective?.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = try store().create(NewTask(title: title, objective: (objective?.isEmpty ?? true) ? nil : objective, projectPath: project, parent: body.parentID))
        return .json(try JSONEncoder().encode(wire(task)))
    }

    private func setStatus(_ id: Int, _ request: HTTPServer.Request) throws -> HTTPServer.Response {
        let body = try JSONDecoder().decode(StatusBody.self, from: request.body)
        guard let status = TaskStatus(rawValue: body.status) else { return fail("unknown status", 400) }
        guard store().get(id) != nil else { return fail("no task \(id)", 404) }
        let task = try store().update(id) { $0.setStatus(status) }
        return .json(try JSONEncoder().encode(wire(task)))
    }

    private func edit(_ id: Int, _ request: HTTPServer.Request) throws -> HTTPServer.Response {
        let body = try JSONDecoder().decode(EditBody.self, from: request.body)
        guard store().get(id) != nil else { return fail("no task \(id)", 404) }
        let title = body.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, title.isEmpty || title.count > 200 { return fail("a task needs a title of up to 200 characters", 400) }
        let task = try store().update(id) {
            if let title { $0.setTitle(title) }
            if let objective = body.objective?.trimmingCharacters(in: .whitespacesAndNewlines), !objective.isEmpty { $0.setObjective(objective) }
        }
        return .json(try JSONEncoder().encode(wire(task, detail: true)))
    }

    /// Done: the task's live sessions are asked to write a result, then ended, then the task is done. With `immediately`
    /// (or when nothing is running) it skips the asking. The asking happens in the background so the page can show
    /// "wrapping up" and a stuck agent can never hold the request.
    private func finish(_ id: Int, immediately: Bool, includeChildren: Bool) async throws -> HTTPServer.Response {
        guard let task = store().get(id) else { return fail("no task \(id)", 404) }
        guard task.status != .done else { return .json(Data(#"{"state":"done"}"#.utf8)) }
        if includeChildren {
            for child in store().children(of: id) where child.status != .done { _ = try await finish(child.id, immediately: immediately, includeChildren: false) }
        }
        let live = try await backend.snapshot().sessions.filter { $0.group?.id == "task-\(id)" }
        if immediately || live.isEmpty {
            await conclude(id, live: live, summary: nil)
            return .json(Data(#"{"state":"done"}"#.utf8))
        }
        guard await finisher.begin(id) else { return .json(Data(#"{"state":"wrapping"}"#.utf8)) }
        let before = task.result, wait = finishWait, store = store(), backend = backend, finisher = finisher
        let me = self
        Task.detached {
            let asked = live.first { $0.capabilities.contains(.prompt) && $0.attention.kind != .blocked && $0.attention.kind != .unknown }
            if let asked {
                try? await backend.prompt(asked.id, text: "The user is marking task #\(id) done. Do not do anything else: record what the task found, decided or changed (two to five sentences, with any links) with the crook CLI exactly as your task context describes it (same path), as `task result \(id) \"<text>\"`. Then stop.")
            }
            let deadline = Date().addingTimeInterval(wait)
            while asked != nil, Date() < deadline {
                if let now = store.get(id)?.result, now != before { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await me.conclude(id, live: live, summary: asked?.attention.summary)
            await finisher.end(id)
        }
        return .json(Data(#"{"state":"wrapping"}"#.utf8))
    }

    /// Ends the sessions, keeps a result (the session's own summary line when none was written) and marks the task done.
    func conclude(_ id: Int, live: [Session], summary: String?) async {
        for session in live { try? await backend.close(session.id) }
        let current = store().get(id)
        _ = try? store().update(id) {
            if current?.result == nil, let summary, !summary.isEmpty { $0.setResult(summary) }
            $0.setStatus(.done)
        }
    }

    /// Brings back one of the task's earlier conversations, in the folder it ran in.
    private func resume(_ id: Int, _ request: HTTPServer.Request) async throws -> HTTPServer.Response {
        let body = try JSONDecoder().decode(ResumeBody.self, from: request.body)
        guard let task = store().get(id) else { return fail("no task \(id)", 404) }
        guard task.sessions.contains(body.sessionID) || task.sessionNotes.contains(where: { $0.id == body.sessionID }) else {
            return fail("that session isn't one of this task's", 400)
        }
        let cwd = task.sessionNotes.first { $0.id == body.sessionID }?.cwd ?? task.projectPath ?? config().resolvedDefaultSessionDirectory
        let sessionID = try await backend.createSession(CreateSessionRequest(
            workingDirectory: URL(fileURLWithPath: cwd), agent: config().resolvedAgentKind, resumeSessionID: body.sessionID, taskID: id))
        if task.status == .done { _ = try? store().update(id) { $0.setStatus(.active) } }
        return .json(try JSONEncoder().encode(SessionRef(sessionID: sessionID.rawValue)))
    }

    private func transcript(_ id: Int, _ request: HTTPServer.Request) -> HTTPServer.Response {
        guard let task = store().get(id), let sid = request.query["session"],
              task.sessions.contains(sid) || task.sessionNotes.contains(where: { $0.id == sid }) else { return fail("no such session on this task", 404) }
        let cwd = task.sessionNotes.first { $0.id == sid }?.cwd ?? task.projectPath ?? config().resolvedDefaultSessionDirectory
        let url = TranscriptPeek.transcriptURL(workingDirectory: cwd, sessionID: sid, home: home)
        guard let text = TranscriptPeek.conversationText(at: url) else { return fail("the transcript is no longer on disk", 404) }
        return .json((try? JSONEncoder().encode(["text": text])) ?? Data())
    }

    private func reopen(_ id: Int) throws -> HTTPServer.Response {
        guard store().get(id) != nil else { return fail("no task \(id)", 404) }
        let task = try store().update(id) { $0.setStatus(.active) }
        return .json(try JSONEncoder().encode(wire(task)))
    }

    /// A task with a session still running is not deleted from under it.
    private func delete(_ id: Int) async throws -> HTTPServer.Response {
        guard store().get(id) != nil else { return fail("no task \(id)", 404) }
        let snapshot = try await backend.snapshot()
        if snapshot.sessions.contains(where: { $0.group?.id == "task-\(id)" }) {
            return fail("end this task's session first", 409)
        }
        if !store().children(of: id).isEmpty { return fail("delete or finish its subtasks first", 409) }
        try store().delete(id)
        return .json(Data("{}".utf8))
    }

    /// Goes to the task's live session if it has one; otherwise starts (or resumes) one in its project and moves the task
    /// out of the inbox. Returns the session's id either way.
    private func start(_ id: Int, fresh: Bool = false) async throws -> HTTPServer.Response {
        guard let task = store().get(id) else { return fail("no task \(id)", 404) }
        let snapshot = try await backend.snapshot()
        if let live = snapshot.sessions.first(where: { $0.group?.id == "task-\(id)" }) {
            return .json(try JSONEncoder().encode(SessionRef(sessionID: live.id.rawValue)))
        }
        let current = config()
        let directory: String
        if let project = task.projectPath, !project.isEmpty {
            let path = canonicalPath(project)
            guard startTargets(config: current).contains(where: { $0.path == path }) else {
                return fail("this task's folder isn't one Shepherd offers: \(project)", 400)
            }
            directory = path
        } else {
            directory = canonicalPath(current.resolvedDefaultSessionDirectory)
        }
        let sessionID = try await backend.createSession(CreateSessionRequest(
            workingDirectory: URL(fileURLWithPath: directory), agent: current.resolvedAgentKind, taskID: id, fresh: fresh))
        if task.status != .active, task.status != .review { _ = try? store().update(id) { $0.setStatus(.active) } }
        return .json(try JSONEncoder().encode(SessionRef(sessionID: sessionID.rawValue)))
    }

    /// Picks a task up from its notes rather than its old conversation: a new session handed the handoff, notes and
    /// workspace (a very long conversation is often better replaced than resumed). Goes to the live session if there is one.
    private func pickUp(_ id: Int) async throws -> HTTPServer.Response {
        guard let task = store().get(id) else { return fail("no task \(id)", 404) }
        _ = try? store().ensureWorkspace(for: id)
        let response = try await start(id, fresh: true)
        if task.status == .done, response.status == 200 { _ = try? store().update(id) { $0.setStatus(.active) } }
        return response
    }

    /// A running session nobody made a task for becomes one: the task takes the session's title and folder and links it.
    private func promote(_ request: HTTPServer.Request) async throws -> HTTPServer.Response {
        let body = try JSONDecoder().decode(FromSessionBody.self, from: request.body)
        let snapshot = try await backend.snapshot()
        guard let session = snapshot.sessions.first(where: { $0.id.rawValue == body.sessionID }) else { return fail("no such session", 404) }
        if let existing = store().findBySession(body.sessionID) { return .json(try JSONEncoder().encode(wire(existing))) }
        let project = session.workingDirectory.map { canonicalPath($0.path) }
        let created = try store().create(NewTask(title: session.title, projectPath: project))
        let task = try store().update(created.id) { $0.linkSession(body.sessionID); $0.recordSession(id: body.sessionID, cwd: project ?? "", title: session.title); $0.setStatus(.active) }
        return .json(try JSONEncoder().encode(wire(task)))
    }
}

/// Symlink-resolved and normalised, the form `startTargets` uses.
private func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
}
