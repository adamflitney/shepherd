import Foundation
import ShepherdCore
import ShepherdTasks

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
    /// Only in the detail response.
    var plan: [PlanStepWire]?
    var log: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, objective, status, branch, pr, updated, plan, log
        case projectPath = "project_path"
        case progressDone = "progress_done"
        case progressTotal = "progress_total"
        case sessionIDs = "session_ids"
    }
}

private func wire(_ task: TaskFile, detail: Bool = false) -> TaskWire {
    let progress = task.progress
    var out = TaskWire(
        id: task.id, title: task.title, objective: task.objective, projectPath: task.projectPath, status: task.status.rawValue,
        progressDone: progress.done, progressTotal: progress.total, sessionIDs: task.sessions, branch: task.branch, pr: task.pr,
        updated: task.updated)
    if detail {
        out.plan = task.plan.map { PlanStepWire(text: $0.text, done: $0.done) }
        out.log = Array(task.logEntries.suffix(40))
    }
    return out
}

private struct ErrorWire: Encodable { let error: String }
private struct SessionRef: Encodable {
    let sessionID: String
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}
private struct NewTaskBody: Decodable {
    let title: String
    let objective: String?
    let projectPath: String?
    enum CodingKeys: String, CodingKey { case title, objective, projectPath = "project_path" }
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
struct TasksAPI {
    let backend: any SessionBackend
    var store: @Sendable () -> TaskStore = { TaskStore() }
    var config: @Sendable () -> ShepherdConfig = { ShepherdConfig.load() }
    /// Done tasks shown on the board (most recently changed first).
    var doneLimit = 15

    func handles(_ path: String) -> Bool { path == "/api/tasks" || path.hasPrefix("/api/tasks/") }

    func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        let parts = request.path.split(separator: "/").map(String.init)
        do {
            if request.method == "GET", parts == ["api", "tasks"] { return try list() }
            if request.method == "POST", parts == ["api", "tasks"] { return try create(request) }
            if request.method == "POST", parts == ["api", "tasks", "from-session"] { return try await promote(request) }
            if parts.count >= 3, parts[0] == "api", parts[1] == "tasks", let id = Int(parts[2]) {
                if request.method == "GET", parts.count == 3 { return try detail(id) }
                if request.method == "POST", parts.count == 4, parts[3] == "status" { return try setStatus(id, request) }
                if request.method == "POST", parts.count == 4, parts[3] == "start" { return try await start(id) }
                if request.method == "POST", parts.count == 4, parts[3] == "edit" { return try edit(id, request) }
                if request.method == "POST", parts.count == 4, parts[3] == "delete" { return try await delete(id) }
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

    private func list() throws -> HTTPServer.Response {
        let all = store().list()
        let open = all.filter { $0.status != .done }
        let done = all.filter { $0.status == .done }.sorted { ($0.updated ?? "") > ($1.updated ?? "") }.prefix(doneLimit)
        return .json(try JSONEncoder().encode((open + done).map { wire($0) }))
    }

    private func detail(_ id: Int) throws -> HTTPServer.Response {
        guard let task = store().get(id) else { return fail("no task \(id)", 404) }
        return .json(try JSONEncoder().encode(wire(task, detail: true)))
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
        let objective = body.objective?.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = try store().create(NewTask(title: title, objective: (objective?.isEmpty ?? true) ? nil : objective, projectPath: project))
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

    /// A task with a session still running is not deleted from under it.
    private func delete(_ id: Int) async throws -> HTTPServer.Response {
        guard store().get(id) != nil else { return fail("no task \(id)", 404) }
        let snapshot = try await backend.snapshot()
        if snapshot.sessions.contains(where: { $0.group?.id == "task-\(id)" }) {
            return fail("end this task's session first", 409)
        }
        try store().delete(id)
        return .json(Data("{}".utf8))
    }

    /// Goes to the task's live session if it has one; otherwise starts (or resumes) one in its project and moves the task
    /// out of the inbox. Returns the session's id either way.
    private func start(_ id: Int) async throws -> HTTPServer.Response {
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
            workingDirectory: URL(fileURLWithPath: directory), agent: current.resolvedAgentKind, taskID: id))
        if task.status == .inbox || task.status == .ready { _ = try? store().update(id) { $0.setStatus(.active) } }
        return .json(try JSONEncoder().encode(SessionRef(sessionID: sessionID.rawValue)))
    }

    /// A running session nobody made a task for becomes one: the task takes the session's title and folder and links it.
    private func promote(_ request: HTTPServer.Request) async throws -> HTTPServer.Response {
        let body = try JSONDecoder().decode(FromSessionBody.self, from: request.body)
        let snapshot = try await backend.snapshot()
        guard let session = snapshot.sessions.first(where: { $0.id.rawValue == body.sessionID }) else { return fail("no such session", 404) }
        if let existing = store().findBySession(body.sessionID) { return .json(try JSONEncoder().encode(wire(existing))) }
        let project = session.workingDirectory.map { canonicalPath($0.path) }
        let created = try store().create(NewTask(title: session.title, projectPath: project))
        let task = try store().update(created.id) { $0.linkSession(body.sessionID); $0.setStatus(.active) }
        return .json(try JSONEncoder().encode(wire(task)))
    }
}

/// Symlink-resolved and normalised, the form `startTargets` uses.
private func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
}
